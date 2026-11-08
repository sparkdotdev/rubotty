# frozen_string_literal: true

require "spec_helper"
require "stringio"

# Telegram has no album update: the parts arrive as separate messages sharing a
# media_group_id, with the caption on one of them and not reliably the first.
RSpec.describe Rubotty::Adapters::Telegram::AlbumBuffer do
  let(:tg) { endpoint("tg") }
  let(:flushed) { [] }
  let(:now) { Time.now }
  let(:clock) { -> { @now ||= now } }

  subject(:buffer) do
    described_class.new(window: 1.0, flush: ->(message) { flushed << message }, clock: clock)
  end

  def advance(seconds) = (@now = (@now || now) + seconds)

  def part(id, text: "", attachment_name: "a.jpg")
    message(
      tg, text: text, native_id: id.to_s,
      attachments: [Rubotty::Core::Attachment.new(kind: :photo, native_ref: attachment_name)]
    )
  end

  after { buffer.stop }

  it "passes a message with no group straight through" do
    single = part(1)
    expect(buffer.offer(single, nil)).to equal(single)
  end

  it "holds a grouped message rather than emitting it immediately" do
    expect(buffer.offer(part(1), "group-a")).to be_nil
    expect(flushed).to be_empty
  end

  it "merges every part into one message once the window closes" do
    buffer.offer(part(1, attachment_name: "a.jpg"), "group-a")
    buffer.offer(part(2, attachment_name: "b.jpg"), "group-a")
    buffer.offer(part(3, attachment_name: "c.jpg"), "group-a")
    advance(2)
    buffer.flush_expired

    expect(flushed.size).to eq(1)
    expect(flushed.first.attachments.map(&:native_ref)).to eq(%w[a.jpg b.jpg c.jpg])
  end

  it "finds the caption wherever Telegram put it" do
    buffer.offer(part(1), "group-a")
    buffer.offer(part(2, text: "the caption"), "group-a")
    advance(2)
    buffer.flush_expired

    expect(flushed.first.body.text).to eq("the caption")
  end

  it "identifies the album by its first part, so the message map stays stable" do
    buffer.offer(part(7), "group-a")
    buffer.offer(part(5), "group-a")
    advance(2)
    buffer.flush_expired

    expect(flushed.first.ref.native_id).to eq("5")
  end

  it "orders attachments by message id, which is the order they were picked" do
    buffer.offer(part(3, attachment_name: "c.jpg"), "group-a")
    buffer.offer(part(1, attachment_name: "a.jpg"), "group-a")
    buffer.offer(part(2, attachment_name: "b.jpg"), "group-a")
    advance(2)
    buffer.flush_expired

    expect(flushed.first.attachments.map(&:native_ref)).to eq(%w[a.jpg b.jpg c.jpg])
  end

  it "keeps separate groups separate" do
    buffer.offer(part(1), "group-a")
    buffer.offer(part(2), "group-b")
    advance(2)
    buffer.flush_expired

    expect(flushed.size).to eq(2)
  end

  it "does not flush before the window has closed" do
    buffer.offer(part(1), "group-a")
    advance(0.2)
    buffer.flush_expired
    expect(flushed).to be_empty
  end

  it "extends the window when a further part arrives" do
    buffer.offer(part(1), "group-a")
    advance(0.8)
    buffer.offer(part(2), "group-a")
    advance(0.5)
    buffer.flush_expired
    expect(flushed).to be_empty
  end

  # Each new part pushes the deadline forward, so the part cap is the backstop;
  # the clock never advances here, so only the cap can flush.
  it "force flushes at the part cap even when parts arrive faster than the window" do
    described_class::MAX_PARTS.times { |i| buffer.offer(part(i + 1), "group-a") }

    expect(flushed.size).to eq(1)
    expect(flushed.first.attachments.size).to eq(described_class::MAX_PARTS)
  end

  it "does not force flush before the cap is reached" do
    (described_class::MAX_PARTS - 1).times { |i| buffer.offer(part(i + 1), "group-a") }
    expect(flushed).to be_empty
  end

  # A part assembled album is still content and must not vanish at shutdown.
  it "flushes everything on shutdown regardless of the window" do
    buffer.offer(part(1), "group-a")
    buffer.flush_all
    expect(flushed.size).to eq(1)
  end

  it "reports whether anything is waiting" do
    expect(buffer.pending?).to be(false)
    buffer.offer(part(1), "group-a")
    expect(buffer.pending?).to be(true)
  end

  # A raise from the flush block used to vanish with nothing logged, and the
  # class took no logger at all, so there was nowhere for it to say anything.
  describe "a flush that raises" do
    let(:logs) { StringIO.new }
    let(:logger) { Rubotty::Log.build(level: "warn", io: logs) }

    subject(:buffer) do
      described_class.new(
        window: 1.0, flush: ->(_message) { raise "downstream boom" }, clock: clock, logger: logger
      )
    end

    it "warns with the group id rather than swallowing the error" do
      buffer.offer(part(1), "group-a")
      advance(2)
      buffer.flush_expired
      expect(logs.string).to include("WARN")
      expect(logs.string).to include("group-a")
    end

    it "does not lose a sibling group flushed in the same pass" do
      other_flushed = []
      mixed = described_class.new(
        window: 1.0, clock: clock, logger: logger,
        flush: ->(message) do
          raise "downstream boom" if message.ref.native_id == "1"

          other_flushed << message
        end
      )
      mixed.offer(part(1), "group-a")
      mixed.offer(part(2), "group-b")
      advance(2)
      mixed.flush_expired
      expect(other_flushed.size).to eq(1)
    end

    it "never raises out of flush_all either, so shutdown completes" do
      buffer.offer(part(1), "group-a")
      expect { buffer.flush_all }.not_to raise_error
      expect(logs.string).to include("group-a")
    end
  end
end
